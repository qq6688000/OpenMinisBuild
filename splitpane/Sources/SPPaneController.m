#import "SPPaneController.h"
#import "SPHost.h"
#import "SPSettings.h"
#import "SPCompat.h"
#import "SPLog.h"
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
// 允许成为 key：面板里的 App 要能弹键盘。默认行为即可，不额外压制。
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
@property (nonatomic, strong) UIImage *bottomSnapshot;
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
    return bar;
}

#pragma mark 启动

- (BOOL)startWithTop:(NSString *)top bottom:(NSString *)bottom windowScene:(UIWindowScene *)scene {
    if (_active || !top.length || !bottom.length) return NO;
    if (!scene) scene = self.foregroundWindowScene;
    if (!scene) return NO;

    SPOverlayWindow *w = [[SPOverlayWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelStatusBar + 100;
    w.backgroundColor = [UIColor blackColor];
    w.frame = scene.coordinateSpace.bounds;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor blackColor];
    w.rootViewController = vc;
    w.hidden = NO;

    UIView *chrome = [self buildChromeWithWidth:w.bounds.size.width];
    chrome.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [vc.view addSubview:chrome];

    SPSplitView *split = [[SPSplitView alloc] initWithFrame:CGRectMake(0, kChromeHeight, w.bounds.size.width,
                                                                       w.bounds.size.height - kChromeHeight)];
    split.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak typeof(self) wself = self;
    split.onSeamMoved = ^{ [wself resizePanes]; };
    [vc.view addSubview:split];

    _window = w;
    _chrome = chrome;
    _split = split;
    _topBundleID = [top copy];
    _bottomBundleID = [bottom copy];

    // 顺序很关键：先把下半屏那个 App 拉到前台，
    // 上面的 App 就自然退到后台（不用按 home —— 这台机器 SBUIController 没有那个方法）。
    [SPHost openApp:bottom suspended:NO completion:^(BOOL ok) {
        SPLog(@"open bottom %@ -> %d", bottom, (int)ok);
    }];

    // 等它退到后台再挂 scene；后台 scene 不会跟前台抢渲染
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if (!self || !self->_window) return;
        SPHost *topHost = [[SPHost alloc] initWithBundleID:top];
        self->_topHost = topHost;
        [topHost attachWhenReady:split.topContainer inWindowScene:scene attempts:8 interval:0.5];
        SPLog(@"top attach diag=%@ live=%d", topHost.lastDiag ?: @"-", (int)topHost.live);

        SPHost *bottomHost = [[SPHost alloc] initWithBundleID:bottom];
        self->_bottomHost = bottomHost;
        [bottomHost attachWhenReady:split.bottomContainer inWindowScene:scene attempts:8 interval:0.5];
        SPLog(@"bottom attach diag=%@ live=%d", bottomHost.lastDiag ?: @"-", (int)bottomHost.live);

        [self resizePanes];
        self->_active = YES;
        [self startHeartbeat];
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
            [self->_topHost refreshLiveness];
            [self->_bottomHost refreshLiveness];
        } @catch (__unused NSException *e) {}
    }];
}

- (void)resizePanes {
    if (!_split) return;
    [_split setNeedsLayout];
    [_split layoutIfNeeded];
    [_topHost setFrameSize:_split.topContainer.bounds.size];
    [_bottomHost setFrameSize:_split.bottomContainer.bounds.size];
}

#pragma mark 操作

- (void)closeTapped {
    [self stopWithCompletion:nil];
}

- (void)swapTapped {
    if (!_bottomBundleID.length) return;
    NSString *t = _topBundleID, *b = _bottomBundleID;
    UIWindowScene *scene = _window.windowScene;
    [self stopWithCompletion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self startWithTop:b bottom:t windowScene:scene];
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
    w.hidden = YES;
    w.rootViewController = nil;
}

- (void)stopWithCompletion:(void (^)(void))completion {
    if (!_active) { if (completion) completion(); return; }
    NSString *main = _topBundleID;
    [self teardown];
    // 交回全屏：系统自己把主 App 拉到前台全屏，用户看不到黑屏帧
    if (main.length) [SPHost openApp:main suspended:NO completion:nil];
    if (completion) completion();
}

@end