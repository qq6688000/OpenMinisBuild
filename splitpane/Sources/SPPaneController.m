#import "SPPaneController.h"
#import "SPHost.h"
#import "SPSettings.h"
#import "SPCompat.h"
#import "SPLog.h"
#import "SPWindowRegistry.h"
#import "SPXfer.h"
#import "SPXferDrag.h"
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
// 用户要求：分隔条可拖，但只有两个停靠位 —— 10/90 或 90/10
static const CGFloat kMinPaneRatio = 0.05;
static const CGFloat kMaxPaneRatio = 0.95;
static const CGFloat kSnapLow = 0.05;    // 5% / 95%
static const CGFloat kSnapHigh = 0.95;   // 95% / 5%
static const BOOL kRatioSnap = YES;      // 拖动时在两档之间吸附

// ---------------------------------------------------------------- 接缝视图

@interface SPSplitView : UIView
@property (nonatomic, strong) UIView *topContainer;
@property (nonatomic, strong) UIView *bottomContainer;
@property (nonatomic, strong) UIView *seam;
@property (nonatomic, strong) UIView *grabber;
@property (nonatomic, assign) CGFloat splitRatio;
@property (nonatomic, assign) BOOL snapping;
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
        _splitRatio = 0.85;   // 默认 85/15：主画面占大头，保证完整可用；副画面缩小但保留
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
    BOOL landscape = (b.size.width > b.size.height);
    if (landscape) {
        // 横屏：改成左右分屏。竖着切 10/90 会得到 {932,40} 这种一条——
        // 横屏下高度只有 430，上下切毫无意义。
        CGFloat seam = kSeamHeight;
        CGFloat usableW = b.size.width - seam;
        // 用户要求：横屏也用 5/95
        CGFloat r = MAX(_splitRatio, 0.05);
        r = MIN(r, 0.95);
        CGFloat topW = round(usableW * r);
        _topContainer.frame = CGRectMake(0, 0, topW, b.size.height);
        _seam.frame = CGRectMake(topW, 0, seam, b.size.height);
        _bottomContainer.frame = CGRectMake(topW + seam, 0, usableW - topW, b.size.height);
        // 抓手改成竖向
        _grabber.frame = CGRectMake((seam - 5) / 2.0, (b.size.height - 64) / 2.0, 5, 64);
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
    if (kRatioSnap && !_snapping) {
        // 拖动过程中实时跟手（限制在 10%~90% 之间），松手时再吸附
        self.splitRatio = MIN(MAX(r, kMinPaneRatio), kMaxPaneRatio);
    } else {
        self.splitRatio = MIN(MAX(r, kMinPaneRatio), kMaxPaneRatio);
    }
    [self setNeedsLayout];
    if (self.onSeamMoved) self.onSeamMoved();
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (kRatioSnap) {
            // 松手吸附到最近的一档：10/90 或 90/10
            CGFloat mid = (_splitRatio < 0.5) ? kSnapLow : kSnapHigh;
            SPLog(@"seam snap: %.2f -> %.2f", _splitRatio, mid);
            _snapping = YES;
            [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut
                             animations:^{ self.splitRatio = mid; }
                             completion:^(BOOL f) { self->_snapping = NO; }];
        }
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

// 拖拽会话期间，系统需要我们的窗口配合触摸分发，这里不做任何拦截
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
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
@property (nonatomic, assign) BOOL lastPhysicalHorizontal;
@property (nonatomic, assign) CFTimeInterval lastOrientationChangeAt;
@property (nonatomic, strong) NSTimer *orientTimer;
@property (nonatomic, strong) UIButton *xferButton;
@property (nonatomic, assign) CGFloat supersededWindowLevel;
@property (nonatomic, assign) CGAffineTransform supersededRootTransform;
@property (nonatomic, assign) CGRect supersededRootFrame;
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


// 取当前方向的屏幕框：设备横屏时把 430x932 换成 932x430。
// windowScene.coordinateSpace.bounds 不随旋转更新，必须自己换算。
static CGRect SPCurrentScreenBounds(void) {
    CGSize s = [UIScreen mainScreen].bounds.size;
    // 系统方向 API 在这台机器上全部失效（日志实证：横屏时仍报 io=1/{430,932}），
    // 所以用加速计判断物理方向，横屏时把屏幕尺寸交换。
    Class mgr = NSClassFromString(@"CMMotionManager");
    if (mgr) {
        @try {
            static id m = nil;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                m = [[mgr alloc] init];
                ((void (*)(id, SEL, double))objc_msgSend)(m, NSSelectorFromString(@"setAccelerometerUpdateInterval:"), 0.1);
                ((void (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"startAccelerometerUpdates"));
            });
            id data = ((id (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"accelerometerData"));
            if (data) {
                SEL accSel = NSSelectorFromString(@"acceleration");
                NSMethodSignature *sig = [data methodSignatureForSelector:accSel];
                typedef struct { double x, y, z; } Vec3;
                if (sig && [sig methodReturnLength] >= sizeof(Vec3)) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:data]; [inv setSelector:accSel]; [inv invoke];
                    Vec3 v; [inv getReturnValue:&v];
                    if (fabs(v.x) > fabs(v.y) * 1.6 && fabs(v.x) > 0.5) {
                        if (s.height > s.width) { CGFloat t = s.width; s.width = s.height; s.height = t; }
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    }
    return CGRectMake(0, 0, s.width, s.height);
}

- (BOOL)spIsPhysicallyHorizontal {
    CGRect b = SPCurrentScreenBounds();
    return b.size.width > b.size.height;
}

- (void)spPollOrientation {
    if (!_window || !_active) return;
    BOOL h = [self spIsPhysicallyHorizontal];
    if (h == _lastPhysicalHorizontal) return;
    // 防抖：方向刚变过 1.5 秒内不再处理，否则重排会反过来影响判定，形成抖动
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastOrientationChangeAt < 1.5) return;
    _lastOrientationChangeAt = now;
    _lastPhysicalHorizontal = h;
    SPLog(@"physical orientation changed horizontal=%d", (int)h);
    [self spOrientationChanged:nil];
}

- (void)spOrientationChanged:(NSNotification *)n {
    if (!_window) return;
    static int probeCount = 0;
    if (probeCount++ < 2) @try { [SPHost dumpOrientationAPIs]; } @catch (__unused NSException *e) {}
    // ⚠️ windowScene.coordinateSpace.bounds 在旋转后仍然是竖屏尺寸（日志实证：横屏时读到 430x932），
    // 不能用它判断方向。用设备方向 + 屏幕尺寸换算出真实屏幕框。
    CGRect b = SPCurrentScreenBounds();
    SPLog(@"orientation changed -> window %@", NSStringFromCGRect(b));
    _window.frame = b;
    _window.rootViewController.view.frame = b;
    _split.frame = CGRectMake(0, kChromeHeight, b.size.width, b.size.height - kChromeHeight);
    [_split setNeedsLayout];
    [_split layoutIfNeeded];
    // 两块按新容器尺寸重排
    [_topHost setFrameSize:_split.topContainer.bounds.size];
    [_bottomHost setFrameSize:_split.bottomContainer.bounds.size];
    // home 条也要挪到新的底部
    _homeBar.frame = CGRectMake(0, b.size.height - 60, b.size.width, 60);
}


// 接缝中央的「传送」按钮：把当前窗口的内容发到另一半
- (void)addXferButtonToView:(UIView *)host {
    CGFloat d = 34;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(host.bounds.size.width - d - 8, 0, d, d);
    b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.85];
    b.layer.cornerRadius = d / 2.0;
    [b setImage:[UIImage systemImageNamed:@"arrow.up.forward.app.fill"] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    b.layer.zPosition = 2600;
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [b addTarget:self action:@selector(xferTapped) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(xferLongPressed:)];
    lp.minimumPressDuration = 0.6;
    [b addGestureRecognizer:lp];
    [host addSubview:b];
    _xferButton = b;
    SPLog(@"xfer button added");
}

- (void)xferLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    SPLog(@"xferLongPressed -> 尝试抓取当前窗口可见文本");
    NSString *txt = [self harvestTextFromView:_split];
    if (txt.length) {
        [UIPasteboard generalPasteboard].string = txt;
        SPLog(@"xferLongPressed: 已复制 %lu 字", (unsigned long)txt.length);
    } else {
        SPLog(@"xferLongPressed: 没抓到文本");
    }
}

// 遍历视图树，把 UILabel / UITextView / UITextField 里的文字拼起来。
// App 的真实内容在 sceneView 里，从这里能拿到当前屏幕上可见的文字。
- (NSString *)harvestTextFromView:(UIView *)root {
    NSMutableArray *out = [NSMutableArray array];
    [self collectText:root into:out depth:0];
    return [out componentsJoinedByString:@"\n"];
}

- (void)collectText:(UIView *)v into:(NSMutableArray *)out depth:(NSInteger)d {
    if (!v || d > 24) return;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) [out addObject:t];
    } else if ([v isKindOfClass:[UITextView class]]) {
        NSString *t = ((UITextView *)v).text;
        if (t.length) [out addObject:t];
    } else if ([v isKindOfClass:[UITextField class]]) {
        NSString *t = ((UITextField *)v).text;
        if (t.length) [out addObject:t];
    }
    for (UIView *sub in v.subviews) [self collectText:sub into:out depth:d + 1];
}

- (void)xferTapped {
    // 目标 = 当前不在焦点的那一半
    NSString *target = SPPaneController.shared.bottomBundleID;
    SPLog(@"xferTapped target=%@", target);
    if (!target.length) return;
    [SPXfer presentSenderForBundleID:target fromWindow:_window inScene:_window.windowScene];
}

- (void)homeBarTapped {
    // 用户决定：上划 Home / 点 Home 条 = 直接拆窗回桌面，不做挂起。
    SPLog(@"homeBarTapped -> 直接拆窗回桌面");
    [self stopWithCompletion:nil];
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
    // 旋转后窗口尺寸会变，vc.view 和里面的 split 都要跟着
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    w.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (@available(iOS 11.0, *)) {
        vc.view.insetsLayoutMarginsFromSafeArea = NO;
        vc.view.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
    }
    SPSplitView *split = [[SPSplitView alloc] initWithFrame:CGRectMake(0, kChromeHeight, w.bounds.size.width,
                                                                       w.bounds.size.height - kChromeHeight - bottomInset)];
    split.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    split.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak typeof(self) wself = self;
    split.onSeamMoved = ^{ [wself resizePanes]; };
    split.onSeamEnded = ^{ [wself flushResize]; };
    [vc.view addSubview:split];
    [vc.view bringSubviewToFront:chrome];
    [self addFloatingButtonsToView:vc.view width:w.bounds.size.width];
    [self addHomeBarToView:vc.view width:w.bounds.size.width height:w.bounds.size.height];
    [self addXferButtonToView:vc.view];
    // 两个 pane 容器都装拖放：PV 的做法 —— 数据由系统 UIDragSession 承载，
    // 我们只保证两个容器处在同一拖拽空间里
    [SPXferDrag attachToContainer:split.topContainer label:@"top"];
    [SPXferDrag attachToContainer:split.bottomContainer label:@"bottom"];

    // 兜底出口：双击画面任意处也能缩成桌面小窗（不依赖点中底部热区）
    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(homeBarTapped)];
    dbl.numberOfTapsRequired = 2;
    dbl.cancelsTouchesInView = NO;
    dbl.delegate = (id<UIGestureRecognizerDelegate>)self;
    [w addGestureRecognizer:dbl];
    _doubleTapExit = dbl;
    SPLog(@"double-tap exit installed");

    // 旋转：这台机器系统不发旋转通知（且方向 API 全失效），
    // 改用 0.5s 轮询物理方向，变了就重排。
    _lastPhysicalHorizontal = [self spIsPhysicallyHorizontal];
    _orientTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        [self spPollOrientation];
    }];

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
        // 实时画面（0.5.2 的做法）：抓真 scene、推容器尺寸让 App 自己重排版
        SPHost *topHost = [[SPHost alloc] initWithBundleID:top];
        self->_topHost = topHost;
        // 实时画面：抓真 scene、推容器尺寸让 App 自己重排版（0.5.2 的做法）
        [topHost attachWhenReady:split.topContainer inWindowScene:scene attempts:12 interval:1.5];
        if (snap) [topHost installSnapshot:snap];
        SPLog(@"top attach diag=%@ live=%d", topHost.lastDiag ?: @"-", (int)topHost.live);

        SPHost *bottomHost = [[SPHost alloc] initWithBundleID:bottom];
        self->_bottomHost = bottomHost;
        [bottomHost attachWhenReady:split.bottomContainer inWindowScene:scene attempts:8 interval:1.5];
        if (snap) [bottomHost installSnapshot:snap];
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
    // 纯快照模式没有活 scene 需要盯，心跳直接不启动（省得空转）
    return;
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



#pragma mark - 悬浮小窗（唯一验证稳定不卡死的挂起方式）

- (void)suspendToFloatingWindow:(void (^)(void))completion {
    if (!_active || !_window) {
        SPLog(@"float abort: active=%d window=%@", (int)_active, _window ? @"Y" : @"nil");
        if (completion) completion();
        return;
    }
    if (_suspended) { if (completion) completion(); return; }
    _suspended = YES;

    CGRect screen = _window.windowScene ? _window.windowScene.coordinateSpace.bounds
                                        : [UIScreen mainScreen].bounds;
    CGFloat cw = screen.size.width * 0.42;
    CGFloat ch = screen.size.height * 0.40;
    CGRect f = CGRectMake(screen.size.width - cw - 18, screen.size.height - ch - 130, cw, ch);
    SPLog(@"float: 缩成悬浮小窗 %@", NSStringFromCGRect(f));

    UIView *v = _window.rootViewController.view;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_window.frame = f;
        v.frame = self->_window.bounds;
        v.transform = CGAffineTransformIdentity;
        v.layer.cornerRadius = 20;
        v.layer.cornerCurve = kCACornerCurveContinuous;
        v.clipsToBounds = YES;
        self->_homeBar.hidden = YES;
        self->_split.singlePaneMode = YES;
        [self->_split setNeedsLayout];
        [self->_split layoutIfNeeded];
    } completion:^(BOOL finished) {
        if (!self->_cardTap) {
            self->_cardTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)];
            [v addGestureRecognizer:self->_cardTap];
        }
        self->_cardTap.enabled = YES;
        SPLog(@"float done");
        if (completion) completion();
    }];
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
    // 统一走悬浮小窗实现：只有这条路在这台机器上不卡死、不黑屏。
    // （窗口下沉 / hidden / 推 scene 后台 三种都试过，都会让 SpringBoard 发黑。）
    [self suspendToFloatingWindow:completion];
    return _suspended;
}

- (void)resumeFromCardWithCompletion:(void (^)(void))completion {
    if (!_suspended || !_window) { if (completion) completion(); return; }
    UIView *v = _window.rootViewController.view;
    if (!v) { if (completion) completion(); return; }

    CGRect full = _window.windowScene ? _window.windowScene.coordinateSpace.bounds
                                      : [UIScreen mainScreen].bounds;
    SPLog(@"resume: 小窗展开回全屏");

    // 窗口层级固定，不动（之前随状态改层级导致闪屏）
    _window.windowLevel = UIWindowLevelStatusBar + 10;

    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_window.frame = full;
        v.frame = self->_window.bounds;
        v.transform = CGAffineTransformIdentity;
        v.layer.cornerRadius = 0;
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


// 取某个 App 的末帧快照（系统快照库里取；取不到返回 nil，容器就留底色，绝不黑）
- (UIImage *)snapshotForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    @try {
        // 1) 如果是当前前台 App，直接截屏最快也最准
        id scene = [SPHost fbSceneForBundleID:bundleID];
        if (scene) {
            SEL shot = NSSelectorFromString(@"snapshot");
            if ([scene respondsToSelector:shot]) {
                id s = ((id (*)(id, SEL))objc_msgSend)(scene, shot);
                SEL surface = NSSelectorFromString(@"IOSurface");
                if (s && [s respondsToSelector:surface]) {
                    // 有 IOSurface 就不折腾了，直接走下面的截图兜底
                }
            }
        }
        // 2) 兜底：截当前屏幕（对刚挂起的 App 最准）
        UIView *win = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isHidden || w.alpha < 0.01) continue;
            if (w.windowLevel > UIWindowLevelStatusBar) continue;
            win = w; break;
        }
        if (!win) return nil;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:win.bounds.size];
        return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
        }];
    } @catch (NSException *e) { SPLog(@"snapshot ex %@", e.reason); }
    return nil;
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