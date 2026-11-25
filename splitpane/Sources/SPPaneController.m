#import "SPPaneController.h"
#import "SPHost.h"
#import "SPSettings.h"
#import "SPCompat.h"
#import "SPLog.h"
#import "SPWindowRegistry.h"
#import "SPRepair.h"
#import "SPParkCard.h"
#import <objc/runtime.h>

// ════════════════════════════════════════════════════════════════════════════
// 竖屏上下分屏
//  · 两块面板各是一个 overlay window，里面放「参考尺寸 = 面板尺寸」的 SBSceneView，
//    App 会按半屏重排（不是缩放整张手机画面）。
//  · 中间接缝可拖 / 可捏，拖只改布局，不重建 scene。
//  · 每块底下垫冻结快照：后台 scene 被系统收走时立刻露出来，绝不黑屏。
//  · 退出 = 把主 App 交回系统全屏（openApp:suspended:NO），再拆窗。
// ════════════════════════════════════════════════════════════════════════════

static const CGFloat kChromeHeight = 0.0;
static const CGFloat kSeamHeight = 26.0;  // 用户要求改回原来的宽度
// 用户要求：分屏比例可以拉到 5/95
static const CGFloat kMinPaneRatio = 0.05;
static const CGFloat kMaxPaneRatio = 0.95;

// ---------------------------------------------------------------- 接缝视图

@interface SPSplitView : UIView
@property (nonatomic, strong) UIView *topContainer;
@property (nonatomic, strong) UIView *bottomContainer;
@property (nonatomic, strong) UIView *seam;
@property (nonatomic, strong) UIView *grabber;
@property (nonatomic, assign) CGFloat splitRatio;
@property (nonatomic, copy) void (^onSeamMoved)(void);
@property (nonatomic, copy) void (^onSeamEnded)(void);
@property (nonatomic, assign) BOOL singlePaneMode;   // 小窗态：只显示上半屏
@end

@implementation SPSplitView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        _topContainer = [UIView new];
        _bottomContainer = [UIView new];
        for (UIView *c in @[_topContainer, _bottomContainer]) {
            c.backgroundColor = [UIColor blackColor];
            // 铺满全屏就该是直角；圆角会让画面四角被切出缺口
            c.layer.cornerRadius = 0;
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
    if (_singlePaneMode) {
        // 小窗态：上半屏铺满，下半屏和缝隙都不显示
        _topContainer.frame = CGRectMake(0, 0, b.size.width, usable);
        _seam.frame = CGRectZero;
        _bottomContainer.frame = CGRectZero;
        _grabber.frame = CGRectZero;
        return;
    }
    CGFloat topH = round((usable - kSeamHeight) * _splitRatio);
    // 容器必须铺满整个屏幕宽度，不留左右内边距（用户要求：容器也铺满全屏）
    CGFloat w = b.size.width;
    _topContainer.frame = CGRectMake(0, 0, w, topH);
    _seam.frame = CGRectMake(0, topH, b.size.width, kSeamHeight);
    _bottomContainer.frame = CGRectMake(0, topH + kSeamHeight, w, usable - topH - kSeamHeight);
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

// 参考 InteractivePiP Duo 0.7.50 的 DPPassthroughWindow：
//   1) hitTest 命中空白 → 返回 nil，事件穿透给系统界面
//   2) 命中真实控件 → 正常分发，不惊动系统窗口栈
//   3) 不抢 keyWindow（Duo 里 canBecomeKeyWindow 是 YES，但它的 sendEvent
//      在触摸开始时只做「聚焦浮窗」，从不向系统推送前台状态）
// 之前我们的窗口是普通 UIWindow 且 canBecomeWindow=YES，
// 每次点击都会让系统重排窗口栈 → 分屏被压到后台 → 露出桌面 → 再回来 = 闪。
@interface SPOverlayWindow : UIWindow
@end
@implementation SPOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 点到自己（没有任何子视图接住）→ 穿透，交给系统
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

- (BOOL)canBecomeKeyWindow { return YES; }

// 触摸一开始就把自己提到最前，别等系统把窗口栈重排完再补
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan && touch.window == self) {
                if (self.windowScene) {
                    @try { [self setWindowLevel:UIWindowLevelStatusBar + 10]; }
                    @catch (__unused NSException *e) {}
                }
                break;
            }
        }
    }
    [super sendEvent:event];
}

@end

@interface SPPaneController ()
@property (nonatomic, strong) SPOverlayWindow *window;
@property (nonatomic, strong) SPSplitView *split;
@property (nonatomic, strong) UIView *chrome;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, assign) BOOL goingHome;
@property (nonatomic, assign) BOOL homePanArmed;
@property (nonatomic, assign) CGFloat homePanStartY;
@property (nonatomic, strong) UITapGestureRecognizer *cardTap;
@property (nonatomic, strong) UIView *homeBar;
@property (nonatomic, strong) UIView *homeBarPill;
@property (nonatomic, strong) UIView *cardBlur;
@property (nonatomic, strong) UITapGestureRecognizer *doubleTapExit;
@property (nonatomic, strong) SPHost *topHost;
@property (nonatomic, strong) SPHost *bottomHost;
@property (nonatomic, copy, readwrite) NSString *topBundleID;
@property (nonatomic, copy, readwrite) NSString *bottomBundleID;
@property (nonatomic, assign, readwrite) BOOL active;
@property (nonatomic, strong) NSTimer *heartbeat;
@property (nonatomic, strong) UIImage *topSnapshot;
@property (nonatomic, assign) BOOL resizeCoalescing;
@property (nonatomic, assign) BOOL pendingResize;
@property (nonatomic, strong) UIImage *bottomSnapshot;
- (void)flushResize;
- (void)startHeartbeat;
@end

void SPHostClearHostedBundleIDs(void);

@implementation SPPaneController

+ (instancetype)shared {
    static SPPaneController *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [SPPaneController new]; });
    return inst;
}


// 两侧悬浮按钮：× 贴左上、交换贴右上，压在上半屏画面之上（用户标记的位置）

// 底部 Home 条：和系统那条长得一样，点一下 / 上划都回桌面。
// 比劫持系统手势可靠得多 —— 系统 Home 手势在我们全屏窗口下面根本收不到，
// 自建一条自己的，用户操作意图明确，也不和 App 内滚动打架。
- (void)addHomeBarToView:(UIView *)host width:(CGFloat)width height:(CGFloat)height {
    UIView *bar = [UIView new];
    // 热区 60pt 高：只做 34pt 太窄，手指从底部上划时经常起手在它外面。
    // 视觉胶囊仍画在底部 34pt 内，上面多出来的 26pt 是透明的可点区域。
    CGFloat barH = 60.0;
    bar.frame = CGRectMake(0, height - barH, width, barH);
    bar.backgroundColor = [UIColor clearColor];
    bar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    bar.layer.zPosition = 2500;
    bar.userInteractionEnabled = YES;

    // 视觉上仿系统 home 指示条
    UIView *pill = [UIView new];
    CGFloat pw = 140, ph = 5;
    pill.frame = CGRectMake((width - pw) / 2.0, barH - 34 + (34 - ph) / 2.0, pw, ph);
    pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
    pill.layer.cornerRadius = ph / 2.0;
    pill.userInteractionEnabled = NO;
    [bar addSubview:pill];

    // 点：回桌面
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(homeBarTapped)];
    [bar addGestureRecognizer:tap];

    // 上划：挂起成卡片
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(homeBarPanned:)];
    pan.maximumNumberOfTouches = 1;
    [bar addGestureRecognizer:pan];

    [host addSubview:bar];
    _homeBar = bar;
    _homeBarPill = pill;
    SPLog(@"home bar added y=%.0f h=%.0f w=%.0f", height - barH, barH, width);
}

- (void)homeBarTapped {
    // 新架构：点 Home 条 = 把分屏缩成桌面小窗，不拆窗口、不惊动系统。
    // 这样桌面立刻可见（窗口本身变小了），而且分屏会话完整保留，点小窗就能回来。
    SPLog(@"homeBarTapped -> suspend to floating card");
    [self suspendToCardWithCompletion:nil];
}

- (void)closePaneTapped {
    // 真正退出分屏（释放全部资源）：只有 × 按钮走这条路
    SPLog(@"closePaneTapped -> stop (真正退出)");
    [self stopWithCompletion:nil];
}

- (void)homeBarPanned:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded &&
        g.state != UIGestureRecognizerStateChanged) return;
    CGFloat dy = -[g translationInView:_window].y;
    if (dy > 60) {
        SPLog(@"homeBarPanned dy=%.0f -> suspend to card", dy);
        [self suspendToCardWithCompletion:nil];
    }
}

- (void)addFloatingButtonsToView:(UIView *)host width:(CGFloat)width {
    CGFloat d = 34.0;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"×" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightLight];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.9] forState:UIControlStateNormal];
    close.frame = CGRectMake(8, 54, d, d);   // 避开状态栏
    close.layer.cornerRadius = d / 2.0;
    close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    close.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    [close addTarget:self action:@selector(closePaneTapped) forControlEvents:UIControlEventTouchUpInside];
    close.layer.zPosition = 2000;
    [host addSubview:close];

    UIButton *swap = [UIButton buttonWithType:UIButtonTypeSystem];
    [swap setTitle:@"交换" forState:UIControlStateNormal];
    swap.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [swap setTitleColor:[UIColor colorWithWhite:1 alpha:0.9] forState:UIControlStateNormal];
    swap.frame = CGRectMake(width - 60 - 8, 54, 60, d);
    swap.layer.cornerRadius = d / 2.0;
    swap.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    swap.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [swap addTarget:self action:@selector(swapTapped) forControlEvents:UIControlEventTouchUpInside];
    swap.layer.zPosition = 2000;
    [host addSubview:swap];
}

#pragma mark 顶部控制条

- (UIView *)buildChromeWithWidth:(CGFloat)width {
    UIView *bar = [UIView new];
    // 顶栏不再占高度也不再涂黑：内容从屏幕最顶端开始，标题/抓手作为透明浮层压在上面
    bar.backgroundColor = [UIColor clearColor];
    bar.frame = CGRectMake(0, 0, width, 28.0);
    bar.userInteractionEnabled = NO;

    UILabel *title = [UILabel new];
    title.text = @"上下分屏";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    title.frame = CGRectMake(0, 0, 120, 24);
    title.textAlignment = NSTextAlignmentCenter;
    title.center = CGPointMake(width / 2.0, 14.0);
    title.layer.shadowColor = [UIColor blackColor].CGColor;
    title.layer.shadowOpacity = 0.8;
    title.layer.shadowRadius = 3;
    title.layer.shadowOffset = CGSizeMake(0, 1);
    title.textColor = [UIColor whiteColor];
    title.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [bar addSubview:title];

    UIImageView *handle = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 56, 5)];
    handle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
    handle.layer.cornerRadius = 2.5;
    handle.center = CGPointMake(width / 2.0, 28.0);
    handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [bar addSubview:handle];

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
                                                                            level:UIWindowLevelStatusBar + 10];
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

    // 底部只留 18pt（home 指示条高度），其余全给画面 —— 用户要求上下铺满
    CGFloat bottomInset = 0.0;
    // 铺满全屏：宽度/高度都取窗口真实 bounds，且关掉安全区域内边距（否则左右会被 insets 缩进）
    vc.view.frame = w.bounds;
    if (@available(iOS 11.0, *)) {
        vc.view.insetsLayoutMarginsFromSafeArea = NO;
        vc.view.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
    }
    SPSplitView *split = [[SPSplitView alloc] initWithFrame:CGRectMake(0, kChromeHeight, w.bounds.size.width,
                                                                       w.bounds.size.height - kChromeHeight - bottomInset)];
    split.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak typeof(self) wself = self;
    split.onSeamMoved = ^{ [wself resizePanes]; };
    split.onSeamEnded = ^{ [wself flushResize]; };
    [vc.view addSubview:split];
    [vc.view bringSubviewToFront:chrome];
    [self addFloatingButtonsToView:vc.view width:w.bounds.size.width];
    [self addHomeBarToView:vc.view width:w.bounds.size.width height:w.bounds.size.height];

    // 兜底出口：双击画面任意处也能缩成桌面小窗（不依赖点中底部热区）
    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(homeBarTapped)];
    dbl.numberOfTapsRequired = 2;
    dbl.cancelsTouchesInView = NO;
    dbl.delegate = (id<UIGestureRecognizerDelegate>)self;
    [w addGestureRecognizer:dbl];
    _doubleTapExit = dbl;
    SPLog(@"double-tap exit installed");

    // 出口 1：三指下滑
    // 单指从底部上划 → 挂起成任务卡片（不退出分屏）
    // ⚠️ 不能依赖系统 SBHomeGesturePanGestureRecognizer：我们全屏窗口 eats 了触摸，
    //    那个 hook 根本收不到（0.5.19 日志实证：一次 pan 都没有）。
    // 用 pan 而不是 swipe：swipe 要等 App 的 sceneView 放行才收得到，
    // 实测（0.5.20 日志）一次都没触发。pan + cancelsTouchesInView=NO 能先抓到手指。
    // 用屏幕边缘手势：从底边 40pt 内起手才算，正是系统 Home 手势的原始区域。
    // 这样不会和 App 内的列表滚动打架（普通 pan 从画面中间滑会误触）。
    UIScreenEdgePanGestureRecognizer *homeUp =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(homePanned:)];
    homeUp.edges = UIRectEdgeBottom;
    homeUp.maximumNumberOfTouches = 1;
    homeUp.cancelsTouchesInView = NO;
    homeUp.delaysTouchesBegan = NO;
    homeUp.delaysTouchesEnded = NO;
    homeUp.delegate = (id<UIGestureRecognizerDelegate>)self;
    // ⚠️ 必须挂在 window 上而不是 vc.view：vc.view 里全是 App 的 sceneView，
    // 触摸先被它们接住，我们的 pan 根本收不到（0.5.21 日志实证：一次 homePan 都没有）。
    [w addGestureRecognizer:homeUp];

    UISwipeGestureRecognizer *escape = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(escapeSwipe:)];
    escape.numberOfTouchesRequired = 3;
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
    _goingHome = NO;   // 新开分屏时复位
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
        // 上半屏往往需要等 App 冷启动，给足 12 次 × 1.5s = 18s 的窗口
        [topHost attachWhenReady:split.topContainer inWindowScene:scene attempts:12 interval:1.5];
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

        // 容器布局稳定后再推一次真实尺寸。建视图那刻 split 还没 layout，
        // 拿到的是错的参考尺寸 —— 结果就是「整张桌面缩放」或「缩成一小块」。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(wself) self2 = wself;
            if (!self2 || !self2->_split) return;
            [self2->_split setNeedsLayout];
            [self2->_split layoutIfNeeded];
            [self2 resizePanes];
            [self2 flushResize];
            SPLog(@"relayout top=%@ bottom=%@",
                  NSStringFromCGSize(self2->_split.topContainer.bounds.size),
                  NSStringFromCGSize(self2->_split.bottomContainer.bounds.size));
        });
    });
    return YES;
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
    [_split setNeedsLayout];
    [_split layoutIfNeeded];
    // 布局立刻改（本地、便宜），但推给远端 scene 要节流：
    // updateSettings 是往 FrontBoard 发的跨进程事务，拖动时每秒 60 次会把整机拖死。
    // 拖动是纯本地重排（改 hostView 的 transform），不涉及任何跨进程调用，
    // 所以每帧直接做，不需要节流，也不会卡。
    [_topHost setFrameSize:_split.topContainer.bounds.size];
    [_bottomHost setFrameSize:_split.bottomContainer.bounds.size];
}

- (void)flushResize {
    // 松手那一刻一定把最终尺寸推一次，保证画面和接缝对齐
    _pendingResize = NO;
    [_split setNeedsLayout];
    [_split layoutIfNeeded];   // 先让容器拿到新 bounds，再让宿主按它重排
    [_topHost setFrameSize:_split.topContainer.bounds.size];
    [_bottomHost setFrameSize:_split.bottomContainer.bounds.size];
}


#pragma mark - 挂起 / 恢复（分屏 → 任务卡片 → 分屏）

// 设计说明：
//   不能拆窗口、不能摘 scene —— 一拆就黑屏（0.5.13 的血泪）。
//   做法是把 window.rootViewController.view 整体缩放并挪到桌面底部，
//   窗口本身尺寸/层级都不动。scene 一直在这块视图里实时渲染，
//   所以卡片上看到的就是活画面，点回来也不过是把这个变换还原。

static const CGFloat kCardScale = 0.30;   // 卡片相对全屏的缩放比

- (CGRect)cardRectInWindow {
    CGRect b = _window.bounds;
    CGFloat w = b.size.width * kCardScale;
    CGFloat h = b.size.height * kCardScale;
    // 停在底部偏上，露出桌面图标
    return CGRectMake((b.size.width - w) / 2.0, b.size.height - h - 90, w, h);
}

- (BOOL)suspendToCardWithCompletion:(void (^)(void))completion {
    if (!_active || !_window) return NO;
    if (_suspended) { if (completion) completion(); return YES; }

    // ===== 新架构：把整个分屏窗口缩成一个桌面悬浮小窗 =====
    // 关键点：
    //   1) 不拆窗口、不摘 scene —— scene 一直在里面实时渲染
    //   2) 完全不调用任何系统「回桌面」API —— 桌面自然会露出来
    //      （窗口本身变小了，桌面上除了这一小块之外都是可见的）
    //   3) 层级从 StatusBar+10 降到 StatusBar+100，让它浮在桌面之上但低于系统弹窗
    //
    // 旧方案是「先让系统回桌面，再想办法把 App 压下去」，这台机器上
    // homePress 全链路不可靠（30 个方法名只有一个存在且转场无效），
    // 所以彻底反过来做：我们不动系统，只动自己的窗口。

    CGRect screen = _window.windowScene.coordinateSpace.bounds;
    // 参照系统 App 切换器的任务卡片形态（用户截图）：
    //   占满全屏高度，宽度约 76%，居中略偏右，顶部留出状态栏，底部留出 Dock。
    CGFloat cw = screen.size.width * 0.76;
    CGFloat ch = screen.size.height * 0.88;
    CGRect cardFrame = CGRectMake(screen.size.width - cw - 26,   // 右侧留一点，露出上一张卡片
                                  (screen.size.height - ch) / 2.0,
                                  cw, ch);

    _suspended = YES;
    SPLog(@"suspend: 缩成任务卡片 frame=%@", NSStringFromCGRect(cardFrame));

    // 卡片态铺一层毛玻璃背景：系统 App 切换器是这个观感
    if (!_cardBlur) {
        UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:eff];
        blur.frame = _window.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blur.userInteractionEnabled = NO;
        blur.alpha = 0;
        [_window insertSubview:blur atIndex:0];
        _cardBlur = blur;
    }
    _cardBlur.hidden = NO;
    _cardBlur.alpha = 0;

    UIView *v = _window.rootViewController.view;

    [UIView animateWithDuration:0.30 delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self->_window.frame = cardFrame;
        v.frame = self->_window.bounds;
        v.transform = CGAffineTransformIdentity;
        v.layer.cornerRadius = 44;
        v.layer.cornerCurve = kCACornerCurveContinuous;
        v.clipsToBounds = YES;
        v.layer.borderWidth = 0;
        // 系统卡片有明显的投影，加一个看起来才像
        v.layer.shadowColor = [UIColor blackColor].CGColor;
        v.layer.shadowOpacity = 0.45;
        v.layer.shadowRadius = 30;
        v.layer.shadowOffset = CGSizeMake(0, 12);
        self->_window.layer.shadowColor = [UIColor blackColor].CGColor;
        self->_window.layer.shadowOpacity = 0.5;
        self->_window.layer.shadowRadius = 34;
        self->_window.layer.shadowOffset = CGSizeMake(0, 14);
        self->_homeBar.hidden = YES;
        // 小窗只有 129x280，两块半屏内容挤进去完全看不清。
        // 改成：小窗里只留上半屏（缩比后正好是一张 App 卡片的样子），
        // 下半屏暂时隐藏，展开时恢复。
        [self->_split setNeedsLayout];
        [self->_split layoutIfNeeded];
        self->_split.singlePaneMode = YES;
        [self->_split setNeedsLayout];
        [self->_split layoutIfNeeded];
    } completion:^(BOOL finished) {
        SPLog(@"suspend done 小窗已就位");
        if (!self->_cardTap) {
            self->_cardTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)];
            [v addGestureRecognizer:self->_cardTap];
        }
        self->_cardTap.enabled = YES;
        if (completion) completion();
    }];
    return YES;
}

- (void)resumeFromCardWithCompletion:(void (^)(void))completion {
    if (!_suspended || !_window) { if (completion) completion(); return; }
    UIView *v = _window.rootViewController.view;
    if (!v) { if (completion) completion(); return; }

    CGRect full = _window.windowScene ? _window.windowScene.coordinateSpace.bounds
                                      : [UIScreen mainScreen].bounds;
    SPLog(@"resume: 小窗展开回全屏分屏");

    [UIView animateWithDuration:0.28 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_window.frame = full;
        v.frame = self->_window.bounds;
        v.transform = CGAffineTransformIdentity;
        v.layer.cornerRadius = 0;
        v.layer.borderWidth = 0;
        v.layer.shadowOpacity = 0;
        self->_window.layer.shadowOpacity = 0;
        self->_cardBlur.alpha = 0;
        self->_homeBar.hidden = NO;
        self->_split.singlePaneMode = NO;
        [self->_split setNeedsLayout];
        [self->_split layoutIfNeeded];
    } completion:^(BOOL finished) {
        self->_suspended = NO;
        self->_cardTap.enabled = NO;
        [self->_topHost setFrameSize:self->_split.topContainer.bounds.size];
        [self->_bottomHost setFrameSize:self->_split.bottomContainer.bounds.size];
        SPLog(@"resume done");
        if (completion) completion();
    }];
}

- (BOOL)suspended { return _suspended; }

- (void)cardTapped:(UITapGestureRecognizer *)g {
    SPLog(@"cardTapped -> resume");
    [self resumeFromCardWithCompletion:nil];
}

#pragma mark 操作

// ⚠️ 窗口层级绝不能在键盘弹出/收起时切换。
// 之前这里在 Normal+1 和 StatusBar+10 之间来回跳，点输入框就会触发一次层级变更，
// 系统要重建窗口顺序 → 画面闪一下（视频实证：一帧分屏一帧桌面）。
// 固定在一个层级，键盘靠 SBMedusaHostedKeyboardWindow（层级 20）自己盖上来。
- (void)spKeyboardShow:(NSNotification *)n { (void)n; }
- (void)spKeyboardHide:(NSNotification *)n { (void)n; }

- (void)homePanned:(UIScreenEdgePanGestureRecognizer *)g {
    // 只认「从底部区域起手 + 明显往上」的那一下，避免和 App 内滚动打架
    UIWindow *win = _window;
    if (!win) return;
    // 手势挂在 window 上，locationInView:win 就是 window 坐标，直接用。
    // 之前多转了一次 convertPoint:fromWindow:nil，结果永远得到 y=0（日志实证）。
    CGPoint p0 = [g locationInView:win];
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            _homePanStartY = p0.y;
            // 从屏幕底部 140pt 内起手才算「上划回桌面」
            // 不再限制起手位置：用户从画面中间往上划也应该能挂起。
            // （0.5.26 日志实证：起手 y=458，被 200pt 的底部判定挡掉了）
            _homePanArmed = YES;
            SPLog(@"homePan began y=%.0f h=%.0f armed=%d", p0.y, win.bounds.size.height, (int)_homePanArmed);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!_homePanArmed) return;
            CGFloat dy = _homePanStartY - p0.y;   // 往上为正值
            if (dy > 140) {   // 位移阈值，避免和 App 内滚动混淆
                SPLog(@"homePan dy=%.0f 触发挂起", dy);
                _homePanArmed = NO;
                SPLog(@"homePan -> suspend to card (dy=%.0f)", dy);
                [self suspendToCardWithCompletion:nil];
            }
            break;
        }
        default:
            _homePanArmed = NO;
            break;
    }
}

// 手势共存：不抢 App 自己的 pan / tap
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
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
    if (!_bottomBundleID.length || !_topBundleID.length) return;
    SPLog(@"swapTapped: 原地交换（不拆窗口）");

    // ⚠️ 绝不能 stop → 重建。那样窗口会消失 0.45 秒，屏幕必然闪一下
    // （用户实测：点交互就闪回桌面）。
    // 正确做法：把两个宿主视图各自从容器里摘下来，互换后重新 attach 到对方容器。
    SPHost *t = _topHost;
    SPHost *b = _bottomHost;
    _topHost = b;
    _bottomHost = t;

    NSString *tb = _topBundleID;
    _topBundleID = _bottomBundleID;
    _bottomBundleID = tb;

    // 先摘（detach 内部会保持 scene 不销毁，只是换容器）
    @try { [t detach]; } @catch (__unused NSException *e) {}
    @try { [b detach]; } @catch (__unused NSException *e) {}

    [_split setNeedsLayout];
    [_split layoutIfNeeded];

    @try { [_topHost attachToContainer:_split.topContainer inWindowScene:_window.windowScene]; }
    @catch (NSException *e) { SPLog(@"swap top attach ex %@", e.reason); }
    @try { [_bottomHost attachToContainer:_split.bottomContainer inWindowScene:_window.windowScene]; }
    @catch (NSException *e) { SPLog(@"swap bottom attach ex %@", e.reason); }

    [_topHost setFrameSize:_split.topContainer.bounds.size];
    [_bottomHost setFrameSize:_split.bottomContainer.bounds.size];
    SPLog(@"swap done top=%@ bottom=%@", _topBundleID, _bottomBundleID);
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
    // 卡片窗口层级很高，不清理会一直挡在桌面上（也会挡点击）
    [SPParkCard dismissAll];

    // ⚠️ 必须最先清空托管表：SPScenePin 会强制这些 App 保持前台，
    // 不清的话退出分屏后它们会被永远钉在前台，回不到桌面。
    SPHostClearHostedBundleIDs();

    SPDumpScenes("before-teardown");

    // 顺序（每步都有日志实证）：
    //   1) 先把「要保留的那个 App」交回系统前台，让系统建自己的全屏呈现
    //   2) 再摘我们的宿主视图 —— 此时系统已经接管，摘掉不会出现空渲染
    //   3) 最后恢复剩余 scene 的尺寸
    // 之前一上来就 detach：scene 失去唯一呈现者且系统还没接管 → 黑屏。
    NSString *keep = _topBundleID ?: _bottomBundleID;

    @try {
        // 先把尺寸恢复成全屏，再交回前台：顺序反了系统会按半屏建呈现
        [_topHost restoreOriginalSceneSettings];
        [_bottomHost restoreOriginalSceneSettings];
        if (keep.length && !_goingHome) {
            [SPHost reactivateApp:keep];
            // 它的 scene 可能停在 contentState=0（日志实证），交回前台也不会自己画，
            // 必须切后台再切回来才会重建渲染
            if (!_goingHome) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { [SPHost forceRecycleApp:keep]; } @catch (__unused NSException *e) {}
            });
            }
        }
        // 兜底：把「被压小」的 scene 全扫一遍恢复（漏掉某个 host 也不会留下残废 App）
        [SPRepair restoreAllScenes];
        SPLog(@"repair report: %@", [SPRepair lastReport]);
    } @catch (NSException *e) { SPLog(@"restore ex %@", e.reason); }

    // 关键：宿主视图延迟摘除，等系统把全屏呈现建起来（0.25s 后），
    // 这样中间不会出现「scene 没有任何呈现者」的黑帧。
    SPHost *keepTop = _topHost, *keepBottom = _bottomHost;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [keepTop detach];
            [keepBottom detach];
        } @catch (__unused NSException *e) {}
    });

    [_heartbeat invalidate];
    _heartbeat = nil;
    _topHost = nil;
    _bottomHost = nil;
    _split = nil;
    _chrome = nil;
    UIWindow *w = _window;
    _window = nil;
    _active = NO;
    // 必须彻底撤掉：只 hidden 不释放会留一个隐形窗口，影响桌面点击/系统手势
    [SPWindowRegistry releaseWindow:w];
    // 兜底：任何一条退出路径漏掉了窗口，这里一并收掉
    [SPWindowRegistry killAll];
    SPDumpScenes("after-teardown");
}

- (void)stopWithCompletion:(void (^)(void))completion {
    if (!_active) { if (completion) completion(); return; }
    NSString *main = _topBundleID ?: _bottomBundleID;
    // teardown 会清空这两个，先存下来给「推后台」用
    NSString *savedTop = _topBundleID;
    NSString *savedBottom = _bottomBundleID;
    // 我们要回桌面，绝不能把 App 再拉回前台（recycle 会把桌面盖掉）
    _goingHome = YES;
    UIWindowScene *savedWindowScene = _window.windowScene;   // 拆窗前存下来
    // windowScene 可能是 Aperture（灵动岛），换成分屏窗口所在的那个正常场景
    if (savedWindowScene) {
        NSString *cn = NSStringFromClass([savedWindowScene class]);
        if ([cn containsString:@"Aperture"]) savedWindowScene = nil;
    }
    if (!savedWindowScene) {
        // 兜底：任一非 Aperture 的 UIWindowScene
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            NSString *cn = NSStringFromClass([sc class]);
            if ([cn containsString:@"Aperture"]) continue;
            savedWindowScene = (UIWindowScene *)sc;
            break;
        }
    }
    _active = NO;

    // ⚠️ 先立刻 hidden，让屏幕立刻露出底下的东西。
    // teardown 里要先摘视图、恢复 scene 尺寸再释放窗口，这几步有耗时，
    // 期间窗口还是可见的就是一块黑色（Duo 源码注释里叫 "solid black rectangle"）。
    @try {
        _window.hidden = YES;
        _window.windowLevel = UIWindowLevelNormal;
        _window.rootViewController.view.transform = CGAffineTransformIdentity;
    } @catch (__unused NSException *e) {}

    [self teardown];          // 内部先摘视图、再恢复 scene 尺寸、最后释放窗口
    SPLog(@"stop: window torn down, main=%@", main);

    // ⚠️ 先真回桌面。之前只 reactivateApp，窗口已经拆了但系统还没建好全屏呈现，
    // 中间那 2~3 秒就是用户看到的黑屏（0.5.20 日志实证）。
    // SPHost homePress 有多条兜底链，比 SBUIController 单点可靠。
    @try { [SPHost dumpHomeAPIs]; } @catch (__unused NSException *e) {}
    BOOL wentHome = NO;
    // 优先用我们自己的 windowScene：它必然是正常 App 场景，
    // 不会是 SBSystemApertureWindowScene（灵动岛，缺方法会抛异常）。
    UIWindowScene *ownScene = savedWindowScene;
    @try { wentHome = [SPHost homePressInWindowScene:ownScene]; } @catch (__unused NSException *e) {}
    if (!wentHome) @try { wentHome = [SPHost homePress]; } @catch (__unused NSException *e) {}
    // homePress 返回 YES 但系统不一定真转场（日志实证），再补一条强制路径。
    // 稍等 0.15s：让窗口真正从窗口栈消失后再让系统转场，否则转场会被我们的窗口挡住。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            BOOL f = [SPHost forceHomeScreen];
            SPLog(@"stop: forceHomeScreen=%d", (int)f);
        } @catch (__unused NSException *e) {}
        // 再补一次 homePress（这次窗口已经彻底没了）
        @try {
            BOOL h2 = [SPHost homePress];
            SPLog(@"stop: homePress retry=%d", (int)h2);
        } @catch (__unused NSException *e) {}
    });
    SPLog(@"stop: homePress=%d (diag=%@)", (int)wentHome, [SPHost homePressDiag]);

    // 兜底 1：直接把两个 App 的 scene 推成后台，SpringBoard 自会显示桌面。
    // （这台机器 homePress 全链路不可用，这是唯一验证有效的方式）
    if (!wentHome) {
        BOOL a = savedTop.length ? [SPHost pushSceneToBackground:savedTop] : NO;
        BOOL b2 = savedBottom.length ? [SPHost pushSceneToBackground:savedBottom] : NO;
        SPLog(@"stop: pushToBackground top=%d bottom=%d", (int)a, (int)b2);
        wentHome = a || b2;
    }

    // 兜底 2：还失败才 reactivate 主 App，至少不是全黑
    if (!wentHome && main.length) {
        [SPHost reactivateApp:main];
        // 再补一次 settings 恢复：activate 之后系统会重新计算全屏布局
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { [SPRepair restoreAllScenes]; } @catch (__unused NSException *e) {}
        });
    }
    if (completion) completion();
}

@end