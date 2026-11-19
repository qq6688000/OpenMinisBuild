#import "DPGestureController.h"
#import "DPWindowManager.h"
#import "DPSettings.h"

@interface DPGestureController () <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *targetView;
@property (nonatomic, strong) NSMutableArray<UIGestureRecognizer *> *recognizers;
@property (nonatomic, strong, nullable) UIScreenEdgePanGestureRecognizer *leftEdge;
@property (nonatomic, strong, nullable) UIScreenEdgePanGestureRecognizer *rightEdge;
@property (nonatomic, strong, nullable) UISwipeGestureRecognizer *threeFingerUp;
@property (nonatomic, strong, nullable) UITapGestureRecognizer *statusBarDoubleTap;
@property (nonatomic, strong, nullable) UILongPressGestureRecognizer *homeIndicatorLongPress;
@end

@implementation DPGestureController

+ (instancetype)shared {
    static DPGestureController *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DPGestureController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _recognizers = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(reloadFromSettings)
                                                     name:kDPSettingsChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)installOnView:(UIView *)view {
    self.targetView = view;
    [self reloadFromSettings];
}

- (void)uninstall {
    for (UIGestureRecognizer *gr in self.recognizers) {
        [gr.view removeGestureRecognizer:gr];
    }
    [self.recognizers removeAllObjects];
    self.leftEdge = nil;
    self.rightEdge = nil;
    self.threeFingerUp = nil;
    self.statusBarDoubleTap = nil;
    self.homeIndicatorLongPress = nil;
}

- (void)reloadFromSettings {
    [self uninstall];
    UIView *view = self.targetView;
    if (!view || ![DPSettings shared].isEnabled) return;

    DPSettings *s = [DPSettings shared];

    if ([s isGestureEnabled:DPActivationGestureEdgeSwipe]) {
        self.leftEdge = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEdge:)];
        self.leftEdge.edges = UIRectEdgeLeft;
        self.leftEdge.delegate = self;
        [view addGestureRecognizer:self.leftEdge];
        [self.recognizers addObject:self.leftEdge];

        self.rightEdge = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEdge:)];
        self.rightEdge.edges = UIRectEdgeRight;
        self.rightEdge.delegate = self;
        [view addGestureRecognizer:self.rightEdge];
        [self.recognizers addObject:self.rightEdge];
    }

    if ([s isGestureEnabled:DPActivationGestureThreeFingerSwipeUp]) {
        self.threeFingerUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleThreeFinger:)];
        self.threeFingerUp.direction = UISwipeGestureRecognizerDirectionUp;
        self.threeFingerUp.numberOfTouchesRequired = 3;
        self.threeFingerUp.delegate = self;
        [view addGestureRecognizer:self.threeFingerUp];
        [self.recognizers addObject:self.threeFingerUp];
    }

    if ([s isGestureEnabled:DPActivationGestureStatusBarDoubleTap]) {
        self.statusBarDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleStatusBarDoubleTap:)];
        self.statusBarDoubleTap.numberOfTapsRequired = 2;
        self.statusBarDoubleTap.delegate = self;
        [view addGestureRecognizer:self.statusBarDoubleTap];
        [self.recognizers addObject:self.statusBarDoubleTap];
    }

    if ([s isGestureEnabled:DPActivationGestureHomeIndicatorLongPress]) {
        self.homeIndicatorLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHomeLongPress:)];
        self.homeIndicatorLongPress.minimumPressDuration = 0.45;
        self.homeIndicatorLongPress.delegate = self;
        [view addGestureRecognizer:self.homeIndicatorLongPress];
        [self.recognizers addObject:self.homeIndicatorLongPress];
    }
}

#pragma mark - Handlers

- (void)handleEdge:(UIScreenEdgePanGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded && gr.state != UIGestureRecognizerStateRecognized) {
        // Trigger once past a sensitivity-scaled threshold
        if (gr.state == UIGestureRecognizerStateChanged) {
            CGPoint t = [gr translationInView:gr.view];
            CGFloat threshold = 40.0 + (1.0 - [DPSettings shared].edgeSwipeSensitivity) * 80.0;
            CGFloat distance = (gr.edges == UIRectEdgeLeft) ? t.x : -t.x;
            if (distance > threshold) {
                // Prevent re-fire: disable temporarily
                gr.enabled = NO;
                gr.enabled = YES;
                [self activate];
            }
        }
        return;
    }
    [self activate];
}

- (void)handleThreeFinger:(UISwipeGestureRecognizer *)gr {
    (void)gr;
    [self activate];
}

- (void)handleStatusBarDoubleTap:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateRecognized) return;
    CGPoint p = [gr locationInView:gr.view];
    // Only accept taps near the top ~status bar region
    CGFloat statusH = 54.0;
    if (@available(iOS 11.0, *)) {
        statusH = MAX(statusH, gr.view.safeAreaInsets.top + 10);
    }
    if (p.y <= statusH) {
        [self activate];
    }
}

- (void)handleHomeLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gr locationInView:gr.view];
    CGFloat homeZone = 28.0;
    if (@available(iOS 11.0, *)) {
        homeZone = MAX(homeZone, gr.view.safeAreaInsets.bottom + 8);
    }
    if (p.y >= gr.view.bounds.size.height - homeZone) {
        [self activate];
    }
}

- (void)activate {
    if (![DPSettings shared].isEnabled) return;
    if ([DPSettings shared].hapticFeedback) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [g impactOccurred];
    }
    [[DPWindowManager shared] handleActivationRequest];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gestureRecognizer; (void)other;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    // Don't steal touches from DualPane chrome itself
    UIView *v = touch.view;
    while (v) {
        if ([NSStringFromClass(v.class) hasPrefix:@"DP"]) return NO;
        v = v.superview;
    }
    return YES;
}

@end
