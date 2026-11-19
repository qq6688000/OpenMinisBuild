#import "DPFloatingWindow.h"
#import "DPSceneHost.h"
#import "DPSettings.h"
#import <math.h>

static const CGFloat kDPTitleBarHeight = 36.0;
static const CGFloat kDPResizeHandle = 44.0;
static const CGFloat kDPMinWidth = 180.0;
static const CGFloat kDPMinHeight = 220.0;

@interface DPFloatingWindow () <UIGestureRecognizerDelegate>
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, strong, readwrite, nullable) DPSceneHost *sceneHost;
@property (nonatomic, strong) UIView *chromeView;
@property (nonatomic, strong) UIView *titleBar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *fullscreenButton;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UIView *resizeHandle;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, assign) CGPoint panStartOrigin;
@property (nonatomic, assign) CGSize resizeStartSize;
@property (nonatomic, assign) CGPoint resizeStartOrigin;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL maximized;
@property (nonatomic, assign) CGRect restoreFrame;
- (CGRect)clampFrame:(CGRect)frame inBounds:(CGRect)bounds;
- (void)leaveMaximizedState;
- (void)updateFullscreenButton;
- (void)layoutSceneIfNeeded;
@end

@implementation DPFloatingWindow

- (instancetype)initWithBundleID:(NSString *)bundleID frame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _bundleID = [bundleID copy];
        _contentOpacity = 1.0;
        _cornerRadiusValue = 16.0;
        _showsBorder = YES;
        _isActive = YES;
        _maximized = NO;
        _restoreFrame = CGRectNull;
        self.clipsToBounds = NO;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 16.0;
        self.layer.shadowOffset = CGSizeMake(0, 8);
        [self buildChrome];
        [self installGestures];
        [self applyAppearance];
    }
    return self;
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (!self.superview) return;

    CGRect bounds = self.superview.bounds;
    BOOL fillsSuperview = fabs(self.frame.origin.x - bounds.origin.x) < 1.0
        && fabs(self.frame.origin.y - bounds.origin.y) < 1.0
        && fabs(self.frame.size.width - bounds.size.width) < 1.0
        && fabs(self.frame.size.height - bounds.size.height) < 1.0;
    if (fillsSuperview && !self.maximized) {
        self.maximized = YES;
        self.restoreFrame = CGRectInset(bounds, 24.0, 72.0);
        [self updateFullscreenButton];
    }
}

#pragma mark - Chrome

- (void)buildChrome {
    self.chromeView = [[UIView alloc] initWithFrame:self.bounds];
    self.chromeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.chromeView.clipsToBounds = YES;
    self.chromeView.layer.cornerRadius = self.cornerRadiusValue;
    if (@available(iOS 13.0, *)) {
        self.chromeView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [self addSubview:self.chromeView];

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.blurView.frame = self.chromeView.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.chromeView addSubview:self.blurView];

    self.titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, kDPTitleBarHeight)];
    self.titleBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.titleBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.25];
    [self.chromeView addSubview:self.titleBar];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(44, 0, self.bounds.size.width - 120, kDPTitleBarHeight)];
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.text = [self displayNameForBundleID:self.bundleID];
    [self.titleBar addSubview:self.titleLabel];

    self.closeButton = [self chromeButtonWithSymbol:@"xmark" action:@selector(closeTapped)];
    self.closeButton.frame = CGRectMake(6, 4, 28, 28);
    [self.titleBar addSubview:self.closeButton];

    self.fullscreenButton = [self chromeButtonWithSymbol:@"arrow.up.left.and.arrow.down.right" action:@selector(fullscreenTapped)];
    self.fullscreenButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.fullscreenButton.frame = CGRectMake(self.bounds.size.width - 36, 4, 28, 28);
    [self.titleBar addSubview:self.fullscreenButton];

    self.contentContainer = [[UIView alloc] initWithFrame:CGRectMake(0, kDPTitleBarHeight,
                                                                     self.bounds.size.width,
                                                                     self.bounds.size.height - kDPTitleBarHeight)];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 深灰底，避免空白时看起来像「蓝屏」
    self.contentContainer.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
    self.contentContainer.clipsToBounds = YES;
    [self.chromeView addSubview:self.contentContainer];

    self.resizeHandle = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width - kDPResizeHandle,
                                                                 self.bounds.size.height - kDPResizeHandle,
                                                                 kDPResizeHandle, kDPResizeHandle)];
    self.resizeHandle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.resizeHandle.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.22];
    self.resizeHandle.layer.cornerRadius = 8.0;
    [self addSubview:self.resizeHandle];

    // Visual grip
    CAShapeLayer *grip = [CAShapeLayer layer];
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (int i = 0; i < 3; i++) {
        CGFloat inset = 10 + i * 5;
        [path moveToPoint:CGPointMake(kDPResizeHandle - inset, kDPResizeHandle - 7)];
        [path addLineToPoint:CGPointMake(kDPResizeHandle - 7, kDPResizeHandle - inset)];
    }
    grip.path = path.CGPath;
    grip.strokeColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
    grip.lineWidth = 1.5;
    grip.lineCap = kCALineCapRound;
    [self.resizeHandle.layer addSublayer:grip];
}

- (UIButton *)chromeButtonWithSymbol:(NSString *)name action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
        UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
        [btn setImage:img forState:UIControlStateNormal];
    } else {
        [btn setTitle:@"•" forState:UIControlStateNormal];
    }
    btn.tintColor = [UIColor whiteColor];
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    btn.layer.cornerRadius = 14;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (NSString *)displayNameForBundleID:(NSString *)bundleID {
    // Prefer LSApplicationProxy if available at runtime
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy && [LSApplicationProxy respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id proxy = [LSApplicationProxy performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
#pragma clang diagnostic pop
        if (proxy && [proxy respondsToSelector:@selector(localizedName)]) {
            NSString *name = [proxy valueForKey:@"localizedName"];
            if (name.length) return name;
        }
    }
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *last = parts.lastObject;
    return last.length ? last.capitalizedString : bundleID;
}

#pragma mark - Gestures

- (void)installGestures {
    UIPanGestureRecognizer *titlePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleTitlePan:)];
    titlePan.delegate = self;
    [self.titleBar addGestureRecognizer:titlePan];

    UIPanGestureRecognizer *resizePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleResizePan:)];
    [self.resizeHandle addGestureRecognizer:resizePan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    pinch.cancelsTouchesInView = YES;
    [self addGestureRecognizer:pinch];
}

- (void)handleTitlePan:(UIPanGestureRecognizer *)gr {
    UIView *superview = self.superview;
    if (!superview) return;

    if (gr.state == UIGestureRecognizerStateBegan) {
        if (self.maximized) {
            CGPoint touch = [gr locationInView:superview];
            CGRect restored = CGRectIsNull(self.restoreFrame)
                ? CGRectInset(superview.bounds, 24.0, 72.0)
                : self.restoreFrame;
            CGFloat relativeX = self.bounds.size.width > 0
                ? [gr locationInView:self].x / self.bounds.size.width : 0.5;
            restored.origin.x = touch.x - restored.size.width * relativeX;
            restored.origin.y = touch.y - kDPTitleBarHeight / 2.0;
            self.frame = [self clampFrame:restored inBounds:superview.bounds];
            [self leaveMaximizedState];
            [self layoutSceneIfNeeded];
        }
        self.panStartOrigin = self.frame.origin;
        [self bringToFront];
        if (self.onFocus) self.onFocus(self);
        [self haptic:UIImpactFeedbackStyleLight];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [gr translationInView:superview];
        CGRect f = self.frame;
        f.origin.x = self.panStartOrigin.x + t.x;
        f.origin.y = self.panStartOrigin.y + t.y;
        f = [self clampFrame:f inBounds:superview.bounds];
        self.frame = f;
    } else if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) {
        if (self.onFrameChanged) self.onFrameChanged(self, self.frame);
    }
}

- (void)handleResizePan:(UIPanGestureRecognizer *)gr {
    UIView *superview = self.superview;
    if (!superview) return;

    if (gr.state == UIGestureRecognizerStateBegan) {
        [self leaveMaximizedState];
        self.resizeStartSize = self.bounds.size;
        self.resizeStartOrigin = self.frame.origin;
        [self bringToFront];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [gr translationInView:superview];
        CGFloat w = MAX(kDPMinWidth, self.resizeStartSize.width + t.x);
        CGFloat h = MAX(kDPMinHeight, self.resizeStartSize.height + t.y);
        // Keep inside screen
        w = MIN(w, superview.bounds.size.width - self.resizeStartOrigin.x);
        h = MIN(h, superview.bounds.size.height - self.resizeStartOrigin.y);
        self.frame = CGRectMake(self.resizeStartOrigin.x, self.resizeStartOrigin.y, w, h);
        [self layoutSceneIfNeeded];
    } else if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) {
        [self.sceneHost commitHostedFrame];
        if (self.onFrameChanged) self.onFrameChanged(self, self.frame);
        [self haptic:UIImpactFeedbackStyleMedium];
    }
}

- (void)handlePinch:(UIPinchGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        [self leaveMaximizedState];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGFloat scale = gr.scale;
        CGRect f = self.frame;
        CGPoint center = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        CGFloat w = MAX(kDPMinWidth, f.size.width * scale);
        CGFloat h = MAX(kDPMinHeight, f.size.height * scale);
        if (self.superview) {
            w = MIN(w, self.superview.bounds.size.width);
            h = MIN(h, self.superview.bounds.size.height);
        }
        CGRect resized = CGRectMake(center.x - w / 2.0, center.y - h / 2.0, w, h);
        self.frame = [self clampFrame:resized inBounds:self.superview.bounds];
        gr.scale = 1.0;
        [self layoutSceneIfNeeded];
    } else if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) {
        [self.sceneHost commitHostedFrame];
        if (self.onFrameChanged) self.onFrameChanged(self, self.frame);
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gr {
    (void)gr;
    [self bringToFront];
    if (self.onFocus) self.onFocus(self);
}

- (CGRect)clampFrame:(CGRect)frame inBounds:(CGRect)bounds {
    frame.size.width = MIN(bounds.size.width, MAX(kDPMinWidth, frame.size.width));
    frame.size.height = MIN(bounds.size.height, MAX(kDPMinHeight, frame.size.height));
    CGFloat maxX = MAX(0, bounds.size.width - frame.size.width);
    CGFloat maxY = MAX(0, bounds.size.height - frame.size.height);
    frame.origin.x = MIN(maxX, MAX(0, frame.origin.x));
    frame.origin.y = MIN(maxY, MAX(0, frame.origin.y));
    return frame;
}

- (void)leaveMaximizedState {
    if (!self.maximized) return;
    self.maximized = NO;
    [self updateFullscreenButton];
}

- (void)updateFullscreenButton {
    if (@available(iOS 13.0, *)) {
        NSString *symbol = self.maximized
            ? @"arrow.down.right.and.arrow.up.left"
            : @"arrow.up.left.and.arrow.down.right";
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12
                                                                                           weight:UIImageSymbolWeightBold];
        [self.fullscreenButton setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg]
                               forState:UIControlStateNormal];
    }
}

#pragma mark - Actions

- (void)closeTapped {
    [self haptic:UIImpactFeedbackStyleMedium];
    if (self.onClose) self.onClose(self);
    else [self closeAnimated:YES completion:nil];
}

- (void)fullscreenTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    UIView *superview = self.superview;
    if (!superview) return;
    CGRect target;
    if (self.maximized) {
        target = CGRectIsNull(self.restoreFrame)
            ? CGRectInset(superview.bounds, 24.0, 72.0)
            : self.restoreFrame;
        target = [self clampFrame:target inBounds:superview.bounds];
        self.maximized = NO;
    } else {
        self.restoreFrame = [self clampFrame:self.frame inBounds:superview.bounds];
        target = superview.bounds;
        self.maximized = YES;
    }
    [self updateFullscreenButton];

    BOOL animate = [DPSettings shared].animateTransitions;
    void (^apply)(void) = ^{
        self.frame = target;
        [self layoutSceneIfNeeded];
    };
    if (animate) {
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4 options:0 animations:apply completion:^(BOOL finished) {
            (void)finished;
            [self.sceneHost commitHostedFrame];
            if (self.onFrameChanged) self.onFrameChanged(self, self.frame);
        }];
    } else {
        apply();
        [self.sceneHost commitHostedFrame];
        if (self.onFrameChanged) self.onFrameChanged(self, self.frame);
    }
}

#pragma mark - Scene

- (void)attachSceneHost:(DPSceneHost *)host {
    if (self.sceneHost == host && host.view.superview == self.contentContainer) {
        [self layoutSceneIfNeeded];
        return;
    }
    if (self.sceneHost) {
        [self.sceneHost.view removeFromSuperview];
    }
    self.sceneHost = host;
    host.view.frame = self.contentContainer.bounds;
    host.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentContainer addSubview:host.view];
    [host setHostedFrame:self.contentContainer.bounds];
}

- (DPSceneHost *)detachSceneHost {
    DPSceneHost *host = self.sceneHost;
    if (!host) return nil;
    [host.view removeFromSuperview];
    self.sceneHost = nil;
    return host;
}

- (void)layoutSceneIfNeeded {
    if (self.sceneHost) {
        [self.sceneHost setHostedFrame:self.contentContainer.bounds];
    }
}

- (void)commitSceneLayout {
    [self.sceneHost commitHostedFrame];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.chromeView.frame = self.bounds;
    self.chromeView.layer.cornerRadius = self.cornerRadiusValue;
    self.titleBar.frame = CGRectMake(0, 0, self.bounds.size.width, kDPTitleBarHeight);
    self.contentContainer.frame = CGRectMake(0, kDPTitleBarHeight,
                                             self.bounds.size.width,
                                             MAX(0, self.bounds.size.height - kDPTitleBarHeight));
    self.resizeHandle.frame = CGRectMake(self.bounds.size.width - kDPResizeHandle,
                                         self.bounds.size.height - kDPResizeHandle,
                                         kDPResizeHandle, kDPResizeHandle);
    [self bringSubviewToFront:self.resizeHandle];
    [self layoutSceneIfNeeded];
}

#pragma mark - Appearance

- (void)setContentOpacity:(CGFloat)contentOpacity {
    _contentOpacity = contentOpacity;
    self.contentContainer.alpha = contentOpacity;
}

- (void)setCornerRadiusValue:(CGFloat)cornerRadiusValue {
    _cornerRadiusValue = cornerRadiusValue;
    self.chromeView.layer.cornerRadius = cornerRadiusValue;
}

- (void)setShowsBorder:(BOOL)showsBorder {
    _showsBorder = showsBorder;
    [self applyAppearance];
}

- (void)applyAppearance {
    if (self.showsBorder) {
        self.chromeView.layer.borderWidth = self.isActive ? 1.5 : 0.5;
        // 用浅白描边，不用 systemBlue（在深色底上容易整块发蓝）
        self.chromeView.layer.borderColor = self.isActive
            ? [UIColor colorWithWhite:1 alpha:0.55].CGColor
            : [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    } else {
        self.chromeView.layer.borderWidth = 0;
    }
    self.layer.shadowOpacity = self.isActive ? 0.4 : 0.25;
}

- (void)setActive:(BOOL)active animated:(BOOL)animated {
    self.isActive = active;
    void (^apply)(void) = ^{ [self applyAppearance]; };
    if (animated) {
        [UIView animateWithDuration:0.18 animations:apply];
    } else {
        apply();
    }
}

- (void)bringToFront {
    [self.superview bringSubviewToFront:self];
}

- (void)closeAnimated:(BOOL)animated completion:(void (^)(void))completion {
    void (^cleanup)(BOOL) = ^(BOOL finished) {
        (void)finished;
        [self.sceneHost invalidate];
        [self removeFromSuperview];
        if (completion) completion();
    };
    if (animated) {
        [UIView animateWithDuration:0.22 animations:^{
            self.alpha = 0;
            self.transform = CGAffineTransformMakeScale(0.92, 0.92);
        } completion:cleanup];
    } else {
        cleanup(YES);
    }
}

- (void)haptic:(UIImpactFeedbackStyle)style {
    if (![DPSettings shared].hapticFeedback) return;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [g impactOccurred];
}

@end
