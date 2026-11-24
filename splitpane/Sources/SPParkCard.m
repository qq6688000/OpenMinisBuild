#import "SPParkCard.h"
#import "SPLog.h"
#import "SPWindowRegistry.h"

// 挂起卡片：用户的当前 App 被「拎起来」停在屏幕下方，点一下拉进分屏。
// PV 在这张卡上托管的是活 scene；本机后台 scene 会被回收，所以只放冻结快照。

@interface SPParkCard ()
- (void)removeNow;


@property (nonatomic, strong) UIImageView *snapshot;
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UIWindow *overlayWindow;
@end

static NSHashTable *SPCards(void) {
    static NSHashTable *t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

@implementation SPParkCard

// 卡片窗口是独立 UIWindow，必须显式清理：只 hidden 会留一个隐形窗口挡住桌面
+ (void)dismissAll {
    NSArray *all = [SPCards() allObjects];
    SPLog(@"dismissAll: %lu card(s)", (unsigned long)all.count);
    for (SPParkCard *c in all) {
        @try { [c removeNow]; } @catch (NSException *e) { SPLog(@"card remove ex %@", e.reason); }
    }
    [SPCards() removeAllObjects];
}

- (void)removeNow {
    [self.layer removeAllAnimations];
    [self removeFromSuperview];
    UIWindow *w = _overlayWindow;
    _overlayWindow = nil;
    [SPWindowRegistry releaseWindow:w];
    SPLog(@"park card removed (%@)", self.bundleID ?: @"?");
}

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
    UIWindow *overlay = [SPWindowRegistry makeWindowWithScene:scene level:UIWindowLevelNormal + 2];
    overlay.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    overlay.rootViewController = vc;
    overlay.hidden = NO;
    _overlayWindow = overlay;
    [SPCards() addObject:self];
    // 兜底：卡片只是「等待你选 App」的临时物，60 秒没人管就自己收掉。
    // 任何漏掉清理的路径都不会在桌面上留黑块。
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if (!self || !self->_overlayWindow) return;
        SPLog(@"park card auto-expired (%@)", self.bundleID ?: @"?");
        [self removeNow];
    });

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
        [self removeNow];
        if (completion) completion();
    }];
}

@end