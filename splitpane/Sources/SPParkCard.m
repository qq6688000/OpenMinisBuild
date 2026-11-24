#import "SPParkCard.h"

// 挂起卡片：用户的当前 App 被「拎起来」停在屏幕下方，点一下拉进分屏。
// PV 在这张卡上托管的是活 scene；本机后台 scene 会被回收，所以只放冻结快照。

@interface SPParkCard ()
@property (nonatomic, strong) UIImageView *snapshot;
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UIWindow *overlayWindow;
@end

@implementation SPParkCard

- (instancetype)initWithSnapshot:(UIImage *)image bundleID:(NSString *)bundleID name:(NSString *)name {
    if ((self = [super initWithFrame:CGRectZero])) {
        _bundleID = [bundleID copy];
        _displayName = [name copy];
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        self.layer.cornerRadius = 28;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;

        _snapshot = [[UIImageView alloc] initWithImage:image];
        _snapshot.contentMode = UIViewContentModeScaleAspectFill;
        _snapshot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _snapshot.frame = self.bounds;
        [self addSubview:_snapshot];

        _title = [[UILabel alloc] init];
        _title.text = name.length ? name : bundleID;
        _title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _title.textColor = UIColor.whiteColor;
        _title.textAlignment = NSTextAlignmentCenter;
        _title.layer.shadowColor = UIColor.blackColor.CGColor;
        _title.layer.shadowOpacity = 1;
        _title.layer.shadowRadius = 6;
        _title.layer.shadowOffset = CGSizeZero;
        _title.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_title];
        [NSLayoutConstraint activateConstraints:@[
            [_title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_title.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_title.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)tapped:(UITapGestureRecognizer *)g {
    [self.delegate parkCardDidTap:self];
}

- (CGRect)restFrame {
    UIWindow *w = self.overlayWindow ?: self.window;
    if (!w) return CGRectZero;
    CGRect b = w.bounds;
    CGFloat height = 128;
    CGFloat width = MIN(360, CGRectGetWidth(b) - 32);
    CGFloat right = CGRectGetMaxX(b) - 14;
    return CGRectMake(right - width, CGRectGetMaxY(b) - height - 14, width, height);
}

- (void)presentInWindowScene:(UIWindowScene *)scene fromRect:(CGRect)fromRect completion:(void (^)(void))completion {
    if (!scene && self.window.windowScene) scene = self.window.windowScene;
    if (!scene) return;
    UIWindow *overlay = [[UIWindow alloc] initWithWindowScene:scene];
    overlay.windowLevel = UIWindowLevelStatusBar + 120;
    overlay.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    overlay.rootViewController = vc;
    overlay.hidden = NO;
    _overlayWindow = overlay;

    CGRect rest = [self restFrame];
    self.frame = fromRect.size.width > 1 ? fromRect : rest;
    self.alpha = fromRect.size.width > 1 ? 0.6 : 1.0;
    [vc.view addSubview:self];
    [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.frame = rest;
        self.alpha = 1.0;
    } completion:^(BOOL finished) { if (completion) completion(); }];
}

- (void)dismissAnimated:(void (^)(void))completion {
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeTranslation(0, 36);
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
        self.overlayWindow.hidden = YES;
        self.overlayWindow.rootViewController = nil;
        self.overlayWindow = nil;
        if (completion) completion();
    }];
}

@end