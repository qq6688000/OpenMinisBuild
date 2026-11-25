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
@property (nonatomic, assign) BOOL homePanArmed;
@property (nonatomic, assign) CGFloat homePanStartY;
@property (nonatomic, strong) UITapGestureRecognizer *cardTap;
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
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
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

    // 出口 1：三指下滑
    // 单指从底部上划 → 挂起成任务卡片（不退出分屏）
    // ⚠️ 不能依赖系统 SBHomeGesturePanGestureRecognizer：我们全屏窗口 eats 了触摸，
    //    那个 hook 根本收不到（0.5.19 日志实证：一次 pan 都没有）。
    // 用 pan 而不是 swipe：swipe 要等 App 的 sceneView 放行才收得到，
    // 实测（0.5.20 日志）一次都没触发。pan + cancelsTouchesInView=NO 能先抓到手指。
    UIPanGestureRecognizer *homeUp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(homePanned:)];
    homeUp.minimumNumberOfTouches = 1;
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
    UIView *v = _window.rootViewController.view;
    if (!v) return NO;

    _suspended = YES;
    SPLog(@"suspend: 分屏缩成卡片");

    CGRect target = [self cardRectInWindow];
    CGFloat scale = kCardScale;

    [UIView animateWithDuration:0.32 delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        v.transform = CGAffineTransformIdentity;
        v.frame = self->_window.bounds;
        v.transform = CGAffineTransformMakeScale(scale, scale);
        v.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        v.layer.cornerRadius = 26;
        v.layer.cornerCurve = kCACornerCurveContinuous;
        v.clipsToBounds = YES;
        v.layer.borderWidth = 2.0;
        v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    } completion:^(BOOL finished) {
        SPLog(@"suspend done rect=%@", NSStringFromCGRect(target));
        // 把窗口本身也收成卡片大小：窗口还是全屏的话会一直盖着桌面，
        // 用户既看不到图标也点不到（0.5.19 黑屏实证）。
        // 这里只改窗口 frame，scene 仍在里面实时渲染。
        self->_window.frame = target;
        v.frame = self->_window.bounds;
        v.transform = CGAffineTransformIdentity;
        v.layer.cornerRadius = 26;
        // 卡片态：点一下回到分屏
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

    SPLog(@"resume: 卡片展开回分屏");
    CGRect full = _window.windowScene ? _window.windowScene.coordinateSpace.bounds : [UIScreen mainScreen].bounds;
    _window.frame = full;
    CGRect b = _window.bounds;

    [UIView animateWithDuration:0.30 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        v.transform = CGAffineTransformIdentity;
        v.frame = b;
        v.center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
        v.layer.cornerRadius = 0;
        v.layer.borderWidth = 0;
    } completion:^(BOOL finished) {
        v.transform = CGAffineTransformIdentity;
        v.frame = b;
        self->_suspended = NO;
        self->_cardTap.enabled = NO;
        [self->_split setNeedsLayout];
        [self->_split layoutIfNeeded];
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

- (void)homePanned:(UIPanGestureRecognizer *)g {
    // 只认「从底部区域起手 + 明显往上」的那一下，避免和 App 内滚动打架
    UIWindow *win = _window;
    if (!win) return;
    // 统一用屏幕坐标，window 自己的 bounds 在缩小态下会变
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGPoint p0 = [g locationInView:win];
    if (win.windowScene) {
        p0 = [g locationInView:nil];
        CGPoint inWin = [win convertPoint:p0 fromWindow:nil];
        p0 = inWin;
    }
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            _homePanStartY = p0.y;
            // 从屏幕底部 140pt 内起手才算「上划回桌面」
            _homePanArmed = (p0.y >= win.bounds.size.height - 140);
            SPLog(@"homePan began y=%.0f h=%.0f armed=%d", p0.y, win.bounds.size.height, (int)_homePanArmed);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!_homePanArmed) return;
            CGFloat dy = _homePanStartY - p0.y;   // 往上为正值
            if (dy > 90) {
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
        if (keep.length) {
            [SPHost reactivateApp:keep];
            // 它的 scene 可能停在 contentState=0（日志实证），交回前台也不会自己画，
            // 必须切后台再切回来才会重建渲染
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { [SPHost forceRecycleApp:keep]; } @catch (__unused NSException *e) {}
            });
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
    _active = NO;
    [self teardown];          // 内部先摘视图、再恢复 scene 尺寸、最后释放窗口
    SPLog(@"stop: window torn down, main=%@", main);

    // ⚠️ 先真回桌面。之前只 reactivateApp，窗口已经拆了但系统还没建好全屏呈现，
    // 中间那 2~3 秒就是用户看到的黑屏（0.5.20 日志实证）。
    // SPHost homePress 有多条兜底链，比 SBUIController 单点可靠。
    BOOL wentHome = NO;
    @try { wentHome = [SPHost homePress]; } @catch (__unused NSException *e) {}
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